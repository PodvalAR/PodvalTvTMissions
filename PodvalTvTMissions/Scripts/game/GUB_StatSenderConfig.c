class StatSender_Config : JsonApiStruct
{
	string Address;
	string Token;

	void StatSender_Config()
	{
		RegV("Address");
		RegV("Token");
	}
}